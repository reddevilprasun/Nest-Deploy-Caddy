import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service.js';
import { CreateProjectDto } from './dto/create-project.dto.js';
import { UpdateProjectDto } from './dto/update-project.dto.js';

@Injectable()
export class ProjectsService {
  constructor(private readonly prisma: PrismaService) {}

  async create(createProjectDto: CreateProjectDto) {
    // Verify owner exists
    const owner = await this.prisma.user.findUnique({
      where: { id: createProjectDto.ownerId },
    });

    if (!owner) {
      throw new NotFoundException(
        `User with ID "${createProjectDto.ownerId}" not found`,
      );
    }

    return this.prisma.project.create({
      data: createProjectDto,
      include: { owner: true },
    });
  }

  async findAll() {
    return this.prisma.project.findMany({
      include: { owner: true },
    });
  }

  async findOne(id: string) {
    const project = await this.prisma.project.findUnique({
      where: { id },
      include: { owner: true },
    });

    if (!project) {
      throw new NotFoundException(`Project with ID "${id}" not found`);
    }

    return project;
  }

  async update(id: string, updateProjectDto: UpdateProjectDto) {
    await this.findOne(id);

    // If ownerId is being updated, verify the new owner exists
    if (updateProjectDto.ownerId) {
      const owner = await this.prisma.user.findUnique({
        where: { id: updateProjectDto.ownerId },
      });

      if (!owner) {
        throw new NotFoundException(
          `User with ID "${updateProjectDto.ownerId}" not found`,
        );
      }
    }

    return this.prisma.project.update({
      where: { id },
      data: updateProjectDto,
      include: { owner: true },
    });
  }

  async remove(id: string) {
    await this.findOne(id);

    return this.prisma.project.delete({
      where: { id },
    });
  }
}
